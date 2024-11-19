use v5.40.0;

use experimental 'class';

class AI::Vector::PgVector {
    use DBI;
    use SQL::SplitStatement;
    use Carp qw(croak);
    use AI::Vector::PgVector::Embeddings::OpenAI;
    use AI::Vector::PgVector::Book;
    use AI::Vector::PgVector::Types qw(
      compile
      NonEmptyStr
      Num
    );

    field $verbose :param :reader = 0;
    field $embedding_size :param  = 1536;
    field $dbh                    = DBI->connect(
        "dbi:Pg:dbname=pgvector_perl_test;host=localhost;port=55431",
        "postgres",
        "mysecretpassword",
        { AutoCommit => 1, RaiseError => 1, }
    );
    field $openai = AI::Vector::PgVector::Embeddings::OpenAI->new;

    method query ( $string, $distance = 1.2 ) {
        state $check = compile( NonEmptyStr, Num );
        ( $string, $distance ) = $check->( $string, $distance );
        my $embedding
          = $self->_vector( $openai->get_embeddings($string)->[0] );
        my $sql = <<~'SQL';
          WITH book_distances AS (
              SELECT b.book_id,
                     b.title,
                     ROUND((be.embedding <=> ?)::numeric, 2) AS rounded_distance,
                     b.summary,
                     g.name AS genre
              FROM   books b
              JOIN   book_genres g      ON b.book_genre_id = g.book_genre_id
              JOIN   book_embeddings be ON b.book_id       = be.book_id
          )
          SELECT   book_id,
                   genre,
                   title,
                   summary,
                   rounded_distance AS distance
          FROM     book_distances
          WHERE    rounded_distance <= ?
          ORDER BY distance
          SQL

       # Use selectall_arrayref instead of selectall_hashref to preserve order
        return [
            map { AI::Vector::PgVector::Book->new( $_->%* ) }
              $dbh->selectall_arrayref(
                $sql, { Slice => {} }, $embedding, $distance
            )->@*
        ];
    }

    method build_db {
        if ( $self->_schema_built ) {
            say STDERR "Database already built" if $verbose;
            return;
        }
        my $schema = $self->_get_schema;
        say STDERR "Building database" if $verbose;
        my @statements = SQL::SplitStatement->new->split($schema);
        for my $statement (@statements) {
            $dbh->do($statement);
        }
        $dbh->do( $self->_get_data );
        say STDERR "Adding embeddings" if $verbose;
        $self->_add_embeddings;
    }

    method _add_embeddings () {

        # Fetch all books that don't have embeddings yet
        my $sth = $dbh->prepare(<<~'SQL');
          SELECT b.book_id, b.title, b.summary 
          FROM books b
          LEFT JOIN book_embeddings be ON b.book_id = be.book_id
          WHERE be.embedding IS NULL
          SQL
        $sth->execute();
        my @books = $sth->fetchall_arrayref()->@*;

        return unless @books;    # Exit if no books need processing

        # Prepare the texts for bulk embedding
        my @texts = map {"$_->[1]. $_->[2]"} @books;

        say "Fetching embeddings for "
          . scalar @texts
          . " texts. Please be patient."
          if $verbose;
        my $embeddings = $openai->get_embeddings( \@texts );

        # Prepare bulk insert
        my $insert_sth = $dbh->prepare(
            "INSERT INTO book_embeddings (book_id, embedding) VALUES (?, ?)");

        $dbh->begin_work;

        try {
            for my $i ( 0 .. $#books ) {
                my $embedding = $self->_vector( $embeddings->[$i] );
                $insert_sth->execute( $books[$i][0], $embedding );
            }
            $dbh->commit;
        }
        catch ($error) {
            $dbh->rollback;
            croak "Failed to insert embeddings: $error";
        }
    }

    method _vector ($embedding) {
        return sprintf '[%s]', join ',', $embedding->@*;
    }

    method rebuild_db {

        # Drop tables in correct order
        $dbh->do("DROP TABLE IF EXISTS book_embeddings CASCADE")
          or croak $dbh->errstr;
        $dbh->do("DROP TABLE IF EXISTS books CASCADE") or croak $dbh->errstr;
        $dbh->do("DROP TABLE IF EXISTS book_genres CASCADE")
          or croak $dbh->errstr;
        $dbh->do("DROP FUNCTION IF EXISTS update_updated_at_column CASCADE")
          or croak $dbh->errstr;

        $self->build_db;
    }

    method _schema_built () {
        my $sth = $dbh->prepare(<<~'SQL');
          SELECT EXISTS (
              SELECT FROM information_schema.tables 
              WHERE table_name = 'books'
          )
          SQL
        $sth->execute();
        my ($exists) = $sth->fetchrow_array();
        return $exists;
    }

    method _get_schema () {
        return sprintf <<~'SQL', $embedding_size;
        CREATE EXTENSION IF NOT EXISTS vector;

        CREATE TABLE book_genres (
            book_genre_id    SERIAL PRIMARY KEY,
            name VARCHAR(50) NOT NULL UNIQUE,
            created_at       TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE books (
            book_id       SERIAL PRIMARY KEY,
            title         VARCHAR(255) NOT NULL,
            summary       TEXT NOT NULL CHECK (LENGTH(summary) <= 4000),
            book_genre_id INTEGER NOT NULL REFERENCES book_genres(book_genre_id),
            created_at    TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            updated_at    TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE book_embeddings (
            book_embedding_id SERIAL PRIMARY KEY,
            book_id          INTEGER NOT NULL REFERENCES books(book_id),
            embedding        vector(%d) NOT NULL,
            created_at       TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            updated_at       TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(book_id)
        );
        
        CREATE INDEX idx_books_genre_id ON books(book_genre_id);
        CREATE INDEX idx_book_embeddings_book_id ON book_embeddings(book_id);
        
        CREATE OR REPLACE FUNCTION update_updated_at_column()
        RETURNS TRIGGER AS $$
        BEGIN
            NEW.updated_at = CURRENT_TIMESTAMP;
            RETURN NEW;
        END;
        $$ language 'plpgsql';
        
        CREATE TRIGGER update_books_updated_at
            BEFORE UPDATE ON books
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at_column();

        CREATE TRIGGER update_book_embeddings_updated_at
            BEFORE UPDATE ON book_embeddings
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at_column();
        
        INSERT INTO book_genres (name) VALUES
            ('Fiction'),
            ('Non-Fiction'),
            ('Science Fiction'),
            ('Mystery'),
            ('Fantasy'),
            ('Horror'); 
        SQL
    }

    method _get_data () {
        return <<~'SQL';
          INSERT INTO books (title, summary, book_genre_id) VALUES
              ('Amara''s Amazing Hair Day', 
              'When Amara wakes up to find her beautiful natural hair has magical powers, she learns to embrace her uniqueness while helping others see the beauty in their own hair. Each protective style she creates grants her a different superpower!',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fantasy')),
          
              ('The Lunar New Year Cat Parade', 
              'Mei''s cat Bao refuses to miss out on the Lunar New Year celebrations. As Mei prepares traditional foods with her grandmother, Bao secretly organizes all the neighborhood cats for a spectacular parade that brings the whole community together.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fiction')),
          
              ('Los Tres Gatos y La Piñata', 
              'Three clever cats living in Mexico City work together to protect a beautiful birthday piñata from a mischievous group of mice. Through teamwork and ingenuity, they learn about friendship while experiencing the joy of a traditional celebration.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fiction')),
          
              ('The Sacred Eagle Feather', 
              'During a powwow celebration, young Jamie from the Lakota tribe learns about the significance of eagle feathers in her culture when she''s tasked with protecting a sacred feather. With guidance from her grandmother, she discovers the deep connection between tradition and respect for nature.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Non-Fiction')),
          
              ('Robot Ramadan', 
              'When young inventor Zahra creates a robot to help her family prepare iftar meals during Ramadan, hilarious chaos ensues. But through the mishaps, she learns the true meaning of the holy month is about community and sharing.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Science Fiction')),
          
              ('The Hidden Temple of Books', 
              'Deepa discovers an ancient temple in Mumbai filled with magical books containing stories from across India. With her magical tabby cat guide, she must protect the sacred stories from being forgotten.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fantasy')),
          
              ('The Great Djembe Detective', 
              'Kofi uses his knowledge of West African drum rhythms to solve mysteries in his neighborhood. When instruments start disappearing before the big cultural festival, he must follow the beats to find the truth.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Mystery')),
          
              ('Abuela''s Time Machine', 
              'Carmen and her grandmother use a magical molcajete to travel through time, witnessing key moments in Mexican-American history while making traditional recipes that hold special meaning to their family.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Science Fiction')),
          
              ('The Night Market Ghost', 
              'During a visit to Singapore''s famous night market, Jun meets a friendly ghost who introduces him to the stories behind traditional foods. Together they help market vendors share their cultural heritage with a new generation.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Horror')),
          
              ('The Diwali Science Fair', 
              'Priya combines her love of science with Diwali celebrations to create an amazing light display for her school''s science fair. Her project teaches everyone about both the festival of lights and solar power.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Non-Fiction')),
          
              ('Dragons Love Dim Sum', 
              'In a magical version of San Francisco''s Chinatown, a young chef discovers that the city''s dragons disguise themselves as humans to enjoy her family''s dim sum restaurant. She must keep their secret while learning to cook dishes that satisfy both human and dragon customers.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fantasy')),
          
              ('The Brooklyn Brownstone Mystery', 
              'When strange noises come from Ms. Thompson''s brownstone, the neighborhood kids assume it''s haunted. But Zara and her detective cat Mr. Midnight discover something unexpected about their community''s history.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Mystery')),
          
              ('The Sari that Touched the Stars', 
              'Inspired by astronaut Kalpana Chawla, young Aisha dreams of space exploration. She creates a spacesuit from her mother''s old sari and ends up on an incredible adventure beyond Earth.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Science Fiction')),
          
              ('The Box of Caribbean Monsters', 
              'When Aiden accidentally opens his grandmother''s old box, he releases friendly versions of Caribbean folklore creatures. With help from local elders, he learns about his heritage while trying to get the creatures back home.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Horror')),
          
              ('The Underground Railroad Code Breakers', 
              'Based on true historical events, follow two brave kids who use quilts and songs to help guide people to freedom, teaching readers about the ingenious ways that escaped slaves communicated along the Underground Railroad.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Mystery'));
        SQL
    }
}

__END__

=head1 NAME

AI::Vector::PgVector - A simple AI module for book recommendations

=head1 SYNOPSIS

    use AI::Vector::PgVector;

    my $pgvector = AI::Vector::PgVector->new( verbose => 1 );

    $pgvector->build_db;
    my $results = $pgvector->query('books about ghosts', 1.3);
    foreach my $book ($results->@*) {
        say $book->to_string;
        say '----';
    }

=head1 DESCRIPTION

This module provides an example module for book recommendations. It uses the
PgVector extension for PostgreSQL to store and query book embeddings. The
embeddings are generated using the OpenAI API.

=head1 METHODS

=head2 new

    my $pgvector = AI::Vector::PgVector->new;

Creates a new instance of the PgVector AI module.

=head3 Arguments

=over 4

=item * C<verbose> - If set to a true value, will print debugging information.

=item * C<embedding_size> - The size of the embeddings to use. Optional. Defaults to 1536.

=back

=head2 query

    my $results = $pgvector->query('books about ghosts', 1.3);

Queries the database for books similar to the given string.

=head3 Arguments

=over 4

=item * C<string> - The search string.

=item * C<distance> - The maximum distance for a book to be considered a match. Optional. Defaults to 1.2.

=back

=head1 METHODS

=head2 build_db

    $pgvector->build_db;

Builds the database schema and adds sample data. Does nothing if the C<books> table
already exists.

=head2 rebuild_db

    $pgvector->rebuild_db;

Rebuilds the database schema and adds sample data.

=head1 LICENCE

MIT

=head1 COPYRIGHT

Curtis "Ovid" Poe, 2024
